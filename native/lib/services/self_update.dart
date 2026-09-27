// In-app self-update for the sideloaded Android build (#1216, slice 2 of
// #1214). Spec: `docs/self-update.md` — R5-R13. The manifest contract there is
// PINNED; this file parses it and nothing else.
//
// Trust chain, in order:
//   1. The manifest is fetched from ONE fixed URL (D2) and its `url` must be
//      https on the SAME host+port (so the manifest can only point at files its
//      own host serves). Redirects are not followed, for the same reason.
//   2. The APK is buffered in memory and its sha256 checked against the
//      manifest BEFORE a byte reaches disk (R8): an unverified APK never exists
//      as a file anything could be pointed at.
//   3. The Kotlin side (`UpdatesChannel.kt`) then refuses the file unless its
//      package name AND signing-certificate set equal the running app's (R10).
//      Steps 1-2 only prove "the host served this"; step 3 proves "our key
//      signed this" (D4). Nothing here can skip step 3: hand-off is the same
//      platform call that verifies.
//
// Platform access goes through [UpdatePlatform] so every rule above is a
// headless test (`test/services/self_update_test.dart`).

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

/// The one distribution manifest (D2). Overridable like the feedback endpoint.
const String updateManifestUrl = String.fromEnvironment(
  'MOBISSH_UPDATE_MANIFEST_URL',
  defaultValue: 'https://mobissh.tailbe5094.ts.net/android-latest.json',
);

/// B, compiled in by the ship script (R2, slice 1). Empty for `flutter run`,
/// test and hand-built APKs — those are never offered an update, because the
/// only other source (the split-per-abi versionCode, `% 1000`) breaks at
/// B=1000 and must not decide an install.
const String mobisshBuildDefine = String.fromEnvironment('MOBISSH_BUILD');

/// The running build ordinal from [define], or null when it is not a positive
/// integer.
int? runningBuildFromDefine(String define) {
  final n = int.tryParse(define.trim());
  return (n != null && n > 0) ? n : null;
}

/// Every self-update failure a user could read, as one type.
class UpdateException implements Exception {
  const UpdateException(this.message);
  final String message;
  @override
  String toString() => message;
}

final RegExp _sha256Pattern = RegExp(r'^[0-9a-f]{64}$');

/// `android-latest.json`, per the pinned contract.
@immutable
class UpdateManifest {
  const UpdateManifest({
    required this.version,
    required this.build,
    required this.abi,
    required this.url,
    required this.sha256,
    this.builtAt,
    this.notes = '',
  });

  /// Parses and VALIDATES [body] fetched from [manifestUrl]. Throws
  /// [UpdateException] for anything that could not be installed safely: a
  /// manifest that cannot be verified is worse than no manifest.
  factory UpdateManifest.parse(String body, {required Uri manifestUrl}) {
    final Object? decoded;
    try {
      decoded = jsonDecode(body);
    } on FormatException catch (e) {
      throw UpdateException('manifest is not JSON (${e.message})');
    }
    if (decoded is! Map<String, dynamic>) {
      throw const UpdateException('manifest is not a JSON object');
    }
    final version = decoded['version'];
    if (version is! String || version.isEmpty) {
      throw const UpdateException('manifest has no version');
    }
    // D1: the integer ordinal is the ONLY thing compared.
    final build = decoded['build'];
    if (build is! int || build <= 0) {
      throw const UpdateException('manifest build is not a positive integer');
    }
    final abi = decoded['abi'];
    if (abi is! String || abi.isEmpty) {
      throw const UpdateException('manifest has no abi');
    }
    final rawUrl = decoded['url'];
    final url = rawUrl is String ? Uri.tryParse(rawUrl) : null;
    if (url == null || url.scheme != 'https') {
      throw const UpdateException('manifest url is not https');
    }
    if (url.host.toLowerCase() != manifestUrl.host.toLowerCase() ||
        url.port != manifestUrl.port) {
      throw UpdateException(
        'manifest url host ${url.host}:${url.port} is not the manifest host '
        '${manifestUrl.host}:${manifestUrl.port}',
      );
    }
    final digest = decoded['sha256'];
    if (digest is! String || !_sha256Pattern.hasMatch(digest)) {
      throw const UpdateException(
        'manifest sha256 is not 64 lowercase hex characters',
      );
    }
    final builtAt = decoded['builtAt'];
    final notes = decoded['notes'];
    return UpdateManifest(
      version: version,
      build: build,
      abi: abi,
      url: url,
      sha256: digest,
      builtAt: builtAt is String ? DateTime.tryParse(builtAt)?.toUtc() : null,
      notes: notes is String ? notes : '',
    );
  }

  final String version;
  final int build;
  final String abi;
  final Uri url;
  final String sha256;
  final DateTime? builtAt;
  final String notes;

  @override
  String toString() => 'UpdateManifest($version, build $build, $abi)';
}

/// What the running platform can do.
@immutable
class UpdateCapabilities {
  const UpdateCapabilities({required this.supported, this.abi = ''});

  /// No updater: desktop, tests, and the Play build whose manifest has neither
  /// the permission nor the provider (R13).
  static const UpdateCapabilities none = UpdateCapabilities(supported: false);

  /// True only when the MERGED manifest carries the updater provider and the
  /// install permission — i.e. the sideload build (R13).
  final bool supported;

  /// The device's primary ABI (`Build.SUPPORTED_ABIS[0]`), for R9.
  final String abi;
}

enum UpdateHandoffStatus {
  /// The system installer was started with the APK.
  launched,

  /// R10 refused the file (package or signing certificate). File deleted.
  refused,

  /// "Install unknown apps" is off; the grant screen was opened (R11).
  needsPermission,

  /// Anything else went wrong on the platform side.
  error,
}

@immutable
class UpdateHandoffResult {
  const UpdateHandoffResult({
    required this.status,
    this.reason = '',
    this.installer = '',
  });

  /// Parses the `verifyAndInstall` payload. Unknown shapes are errors, never
  /// "launched".
  factory UpdateHandoffResult.fromPayload(Object? raw) {
    if (raw is! Map) {
      return const UpdateHandoffResult(
        status: UpdateHandoffStatus.error,
        reason: 'unexpected platform reply',
      );
    }
    final status = UpdateHandoffStatus.values.firstWhere(
      (s) => s.name == raw['status'],
      orElse: () => UpdateHandoffStatus.error,
    );
    final reason = raw['reason'];
    final installer = raw['installer'];
    return UpdateHandoffResult(
      status: status,
      reason: reason is String ? reason : '',
      installer: installer is String ? installer : '',
    );
  }

  final UpdateHandoffStatus status;
  final String reason;

  /// The package that received the install intent (the system installer).
  final String installer;
}

/// The native half. See `UpdatesChannel.kt`.
abstract class UpdatePlatform {
  Future<UpdateCapabilities> capabilities();

  /// `<cacheDir>/updates` — the ONLY directory the updater FileProvider
  /// exposes (`res/xml/update_paths.xml`).
  Future<Directory> updatesDir();

  /// R10 verify, then R11 hand-off. One call so a hand-off can never happen
  /// without the verification.
  Future<UpdateHandoffResult> verifyAndInstall(String path);
}

const String updatesChannelName = 'mobissh/updates';
const MethodChannel updatesChannel = MethodChannel(updatesChannelName);

class ChannelUpdatePlatform implements UpdatePlatform {
  const ChannelUpdatePlatform({this.channel = updatesChannel});

  final MethodChannel channel;

  @override
  Future<UpdateCapabilities> capabilities() async {
    if (!Platform.isAndroid) return UpdateCapabilities.none;
    try {
      final raw = await channel.invokeMethod<Map<Object?, Object?>>(
        'capabilities',
      );
      if (raw == null) return UpdateCapabilities.none;
      final abi = raw['abi'];
      return UpdateCapabilities(
        supported: raw['supported'] == true,
        abi: abi is String ? abi : '',
      );
    } catch (e) {
      debugPrint('update: capabilities unavailable ($e)');
      return UpdateCapabilities.none;
    }
  }

  @override
  Future<Directory> updatesDir() async {
    // path_provider's temporary directory IS Context.getCacheDir() on Android,
    // the root the FileProvider's <cache-path> resolves against.
    final cache = await getTemporaryDirectory();
    return Directory('${cache.path}/updates');
  }

  @override
  Future<UpdateHandoffResult> verifyAndInstall(String path) async {
    try {
      final raw = await channel.invokeMethod<Object?>(
        'verifyAndInstall',
        <String, Object?>{'path': path},
      );
      return UpdateHandoffResult.fromPayload(raw);
    } catch (e) {
      return UpdateHandoffResult(
        status: UpdateHandoffStatus.error,
        reason: '$e',
      );
    }
  }
}

enum UpdateCheckKind {
  /// No updater on this build/platform — show nothing at all (R13).
  unsupported,

  /// A newer build for this device.
  available,

  /// The published build is not newer.
  upToDate,

  /// A manifest was read but cannot be offered (bad contract, ABI mismatch,
  /// unknown running build). [UpdateCheckResult.reason] says why (R9).
  notOffered,

  /// Off-tailnet, timed out, HTTP error. Quiet (R6).
  unreachable,
}

@immutable
class UpdateCheckResult {
  const UpdateCheckResult._(
    this.kind, {
    this.manifest,
    this.installedBuild,
    this.reason = '',
  });

  const UpdateCheckResult.unsupported() : this._(UpdateCheckKind.unsupported);
  const UpdateCheckResult.available(
    UpdateManifest manifest, {
    required int installedBuild,
  }) : this._(
         UpdateCheckKind.available,
         manifest: manifest,
         installedBuild: installedBuild,
       );
  const UpdateCheckResult.upToDate({int? installedBuild, UpdateManifest? manifest})
    : this._(
        UpdateCheckKind.upToDate,
        installedBuild: installedBuild,
        manifest: manifest,
      );
  const UpdateCheckResult.notOffered(String reason, {UpdateManifest? manifest})
    : this._(UpdateCheckKind.notOffered, reason: reason, manifest: manifest);
  const UpdateCheckResult.unreachable(String reason)
    : this._(UpdateCheckKind.unreachable, reason: reason);

  final UpdateCheckKind kind;
  final UpdateManifest? manifest;
  final int? installedBuild;
  final String reason;

  @override
  String toString() => 'UpdateCheckResult($kind, $manifest, $reason)';
}

/// Fetches the manifest and decides whether to offer it.
class UpdateChecker {
  UpdateChecker({
    required this.client,
    required this.platform,
    required this.runningBuild,
    Uri? manifestUrl,
    this.timeout = const Duration(seconds: 8),
  }) : manifestUrl = manifestUrl ?? Uri.parse(updateManifestUrl);

  final http.Client client;
  final UpdatePlatform platform;
  final Uri manifestUrl;
  final int? runningBuild;
  final Duration timeout;

  Future<UpdateCheckResult> check() async {
    final caps = await platform.capabilities();
    // R13: no updater → not even a request.
    if (!caps.supported) return const UpdateCheckResult.unsupported();

    final http.Response response;
    try {
      response = await client.get(manifestUrl).timeout(timeout);
    } on TimeoutException {
      return UpdateCheckResult.unreachable(
        'timed out after ${timeout.inSeconds}s',
      );
    } catch (e) {
      return UpdateCheckResult.unreachable(_describe(e));
    }
    if (response.statusCode != 200) {
      return UpdateCheckResult.unreachable('HTTP ${response.statusCode}');
    }

    final UpdateManifest manifest;
    try {
      manifest = UpdateManifest.parse(response.body, manifestUrl: manifestUrl);
    } on UpdateException catch (e) {
      return UpdateCheckResult.notOffered('manifest rejected: ${e.message}');
    }

    final running = runningBuild;
    if (running == null) {
      return UpdateCheckResult.notOffered(
        'this build carries no MOBISSH_BUILD ordinal, so it cannot compare',
        manifest: manifest,
      );
    }
    if (manifest.build <= running) {
      return UpdateCheckResult.upToDate(
        installedBuild: running,
        manifest: manifest,
      );
    }
    // R9 / D5: never offer an APK this device cannot run.
    if (manifest.abi != caps.abi) {
      return UpdateCheckResult.notOffered(
        'published build is ${manifest.abi}; this device is '
        '${caps.abi.isEmpty ? 'unknown' : caps.abi}',
        manifest: manifest,
      );
    }
    return UpdateCheckResult.available(manifest, installedBuild: running);
  }

  static String _describe(Object e) {
    if (e is SocketException) {
      return e.osError?.message.isNotEmpty == true
          ? '${e.message}: ${e.osError!.message}'
          : e.message;
    }
    if (e is http.ClientException) return e.message;
    return '$e';
  }
}

enum UpdateStage {
  idle,
  downloading,
  verifying,
  handingOff,

  /// The system installer has the APK; the rest is its dialog.
  handedOff,

  /// "Install unknown apps" must be granted first (R11) — persistent.
  needsPermission,
  failed,
}

/// Shown persistently (banner + Settings) when R11 sent the user to the grant
/// screen — never a vanishing toast.
const String kNeedsInstallPermissionMessage =
    'Allow MobiSSH to install unknown apps in the screen that just opened, '
    'then tap Install again.';

@immutable
class UpdateProgress {
  const UpdateProgress({
    required this.stage,
    this.received = 0,
    this.total,
    this.message,
    this.installer = '',
  });

  static const UpdateProgress idle = UpdateProgress(stage: UpdateStage.idle);

  /// On [UpdateStage.handedOff]: the package the install intent reached.
  final String installer;

  final UpdateStage stage;
  final int received;

  /// Null when the server sent no Content-Length.
  final int? total;
  final String? message;

  /// Null = indeterminate, which is what the bar should show.
  double? get fraction {
    final t = total;
    return (t == null || t <= 0) ? null : received / t;
  }

  bool get isBusy =>
      stage == UpdateStage.downloading ||
      stage == UpdateStage.verifying ||
      stage == UpdateStage.handingOff;
}

/// Downloaded APKs are named by build so R12 cleanup can tell an installed
/// build from a pending one.
final RegExp _apkName = RegExp(r'^mobissh-update-(\d+)\.apk$');

/// Downloads, verifies and hands off one build.
class UpdateInstaller {
  UpdateInstaller({required this.client, required this.platform});

  final http.Client client;
  final UpdatePlatform platform;

  /// Guard against a hostile or broken server streaming forever into memory.
  /// Release APKs are ~30 MB.
  static const int maxApkBytes = 256 * 1024 * 1024;

  Stream<UpdateProgress> install(UpdateManifest manifest) async* {
    File? written;
    try {
      final request = http.Request('GET', manifest.url)
        // The manifest's same-host rule is checked on `url`; a redirect would
        // quietly move the download somewhere else.
        ..followRedirects = false;
      final response = await client.send(request);
      if (response.statusCode != 200) {
        yield UpdateProgress(
          stage: UpdateStage.failed,
          message: 'download failed: HTTP ${response.statusCode}',
        );
        return;
      }
      final total = response.contentLength;
      final buffer = BytesBuilder(copy: false);
      yield UpdateProgress(stage: UpdateStage.downloading, total: total);
      await for (final chunk in response.stream) {
        buffer.add(chunk);
        if (buffer.length > maxApkBytes) {
          yield const UpdateProgress(
            stage: UpdateStage.failed,
            message: 'download failed: larger than any APK we publish',
          );
          return;
        }
        yield UpdateProgress(
          stage: UpdateStage.downloading,
          received: buffer.length,
          total: total,
        );
      }

      // R8: verify BEFORE anything touches disk.
      yield const UpdateProgress(stage: UpdateStage.verifying);
      final bytes = buffer.takeBytes();
      final digest = _hex((await Sha256().hash(bytes)).bytes);
      if (digest != manifest.sha256) {
        yield UpdateProgress(
          stage: UpdateStage.failed,
          message:
              'checksum mismatch: expected ${manifest.sha256}, got $digest',
        );
        return;
      }

      final dir = await platform.updatesDir();
      await dir.create(recursive: true);
      final apk = File('${dir.path}/mobissh-update-${manifest.build}.apk');
      written = apk;
      await apk.writeAsBytes(bytes, flush: true);

      yield const UpdateProgress(stage: UpdateStage.handingOff);
      final result = await platform.verifyAndInstall(apk.path);
      switch (result.status) {
        case UpdateHandoffStatus.launched:
          written = null; // the installer reads it now; R12 removes it later
          yield UpdateProgress(
            stage: UpdateStage.handedOff,
            message: 'Follow the Android installer to finish.',
            installer: result.installer,
          );
        case UpdateHandoffStatus.refused:
          yield UpdateProgress(
            stage: UpdateStage.failed,
            message: 'Refused: ${result.reason}',
          );
        case UpdateHandoffStatus.needsPermission:
          yield const UpdateProgress(
            stage: UpdateStage.needsPermission,
            message: kNeedsInstallPermissionMessage,
          );
        case UpdateHandoffStatus.error:
          yield UpdateProgress(
            stage: UpdateStage.failed,
            message: 'install failed: ${result.reason}',
          );
      }
    } catch (e) {
      yield UpdateProgress(stage: UpdateStage.failed, message: '$e');
    } finally {
      // R12: anything not handed to the installer is removed at once (the
      // platform already deleted a refused file; this makes it certain).
      final leftover = written;
      if (leftover != null) {
        try {
          if (leftover.existsSync()) leftover.deleteSync();
        } catch (e) {
          debugPrint('update: could not remove ${leftover.path} ($e)');
        }
      }
    }
  }

  /// R12: on launch, remove every downloaded APK that is already installed
  /// (build <= running) or not ours. A NEWER one is kept: the installer dialog
  /// may still be reading it if the process was killed mid-install.
  Future<void> cleanup({required int? runningBuild}) async {
    try {
      if (!(await platform.capabilities()).supported) return;
      final dir = await platform.updatesDir();
      if (!dir.existsSync()) return;
      for (final entry in dir.listSync()) {
        final name = entry.uri.pathSegments.lastWhere(
          (s) => s.isNotEmpty,
          orElse: () => '',
        );
        final m = _apkName.firstMatch(name);
        final build = m == null ? null : int.parse(m.group(1)!);
        final stale =
            build == null || (runningBuild != null && build <= runningBuild);
        if (stale) entry.deleteSync(recursive: true);
      }
    } catch (e) {
      debugPrint('update: cleanup failed ($e)');
    }
  }

  static String _hex(List<int> bytes) {
    final sb = StringBuffer();
    for (final b in bytes) {
      sb.write(b.toRadixString(16).padLeft(2, '0'));
    }
    return sb.toString();
  }
}
