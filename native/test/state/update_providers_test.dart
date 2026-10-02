// #1258 R14/R15 — the update notifier: pre-download only on an unmetered
// network, and the resume after the "install unknown apps" grant hands off
// exactly once with the already-verified file (no second download, no second
// Install tap).
import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:mobissh/services/self_update.dart';
import 'package:mobissh/state/lifecycle_providers.dart';
import 'package:mobissh/state/update_providers.dart';

final Uri manifestUrl =
    Uri.parse('https://mobissh.tailbe5094.ts.net/android-latest.json');

class FakePlatform implements UpdatePlatform {
  FakePlatform(this.dir);
  final Directory dir;
  bool unmetered = true;
  bool canInstall = true;
  UpdateHandoffStatus next = UpdateHandoffStatus.launched;
  final List<String> handedOff = <String>[];

  @override
  Future<UpdateCapabilities> capabilities() async =>
      const UpdateCapabilities(supported: true, abi: 'arm64-v8a');
  @override
  Future<Directory> updatesDir() async => dir;
  @override
  Future<bool> isUnmetered() async => unmetered;
  @override
  Future<bool> canInstallPackages() async => canInstall;
  @override
  Future<UpdateHandoffResult> verifyAndInstall(String path) async {
    handedOff.add(path);
    return UpdateHandoffResult(status: next);
  }
}

void main() {
  late Directory tmp;
  late FakePlatform platform;
  late int requests;
  final apk = List<int>.generate(32 * 1024, (i) => i % 239);
  late UpdateManifest manifest;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    tmp = Directory.systemTemp.createTempSync('update_providers_test');
    platform = FakePlatform(Directory('${tmp.path}/updates'));
    requests = 0;
    final sha = (await Sha256().hash(apk))
        .bytes
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
    manifest = UpdateManifest.parse(
      jsonEncode(<String, Object?>{
        'version': '0.1.13+199',
        'build': 199,
        'abi': 'arm64-v8a',
        'url': 'https://mobissh.tailbe5094.ts.net/m-199.apk',
        'sha256': sha,
        'notes': 'What changed',
      }),
      manifestUrl: manifestUrl,
    );
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  ProviderContainer makeContainer(UpdateCheckResult result) {
    final client = MockClient.streaming((req, _) async {
      requests++;
      return http.StreamedResponse(Stream.value(apk), 200,
          contentLength: apk.length);
    });
    final c = ProviderContainer(overrides: [
      updatePlatformProvider.overrideWithValue(platform),
      updateHttpClientProvider.overrideWithValue(client),
      updateCheckProvider.overrideWith((ref) async => result),
    ]);
    addTearDown(c.dispose);
    return c;
  }

  Future<void> settle(ProviderContainer c, bool Function() done) async {
    // Bounded poll (10s): the first sha256 in a fresh isolate is JIT-slow.
    for (var i = 0; i < 1000 && !done(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }

  group('R14 pre-download trigger', () {
    test('available + unmetered → downloads once and the state is ready',
        () async {
      final c = makeContainer(
          UpdateCheckResult.available(manifest, installedBuild: 198));
      c.read(updatePrefetchProvider);
      await settle(c, () => c.read(updateDownloadProvider).stage ==
          UpdateStage.ready);
      expect(c.read(updateDownloadProvider).stage, UpdateStage.ready);
      expect(requests, 1);
      expect(platform.handedOff, isEmpty);
    });

    test('available + metered → no request, state idle', () async {
      platform.unmetered = false;
      final c = makeContainer(
          UpdateCheckResult.available(manifest, installedBuild: 198));
      c.read(updatePrefetchProvider);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(requests, 0);
      expect(c.read(updateDownloadProvider).stage, UpdateStage.idle);
    });

    test('up to date → no request', () async {
      final c = makeContainer(
          const UpdateCheckResult.upToDate(installedBuild: 199));
      c.read(updatePrefetchProvider);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(requests, 0);
    });

    test('Install after a pre-download hands off with no second request',
        () async {
      final c = makeContainer(
          UpdateCheckResult.available(manifest, installedBuild: 198));
      c.read(updatePrefetchProvider);
      await settle(c, () => c.read(updateDownloadProvider).stage ==
          UpdateStage.ready);
      await c.read(updateDownloadProvider.notifier).start(manifest);
      expect(requests, 1);
      expect(c.read(updateDownloadProvider).stage, UpdateStage.handedOff);
      expect(platform.handedOff, hasLength(1));
    });
  });

  test('a failure of an older build does not block pre-downloading a newer '
      'one; the failed build itself is not re-fetched', () async {
    platform.next = UpdateHandoffStatus.refused;
    platform.unmetered = false;
    final c = makeContainer(
        UpdateCheckResult.available(manifest, installedBuild: 198));
    final notifier = c.read(updateDownloadProvider.notifier);
    await notifier.start(manifest);
    expect(c.read(updateDownloadProvider).stage, UpdateStage.failed);
    platform.unmetered = true;
    await notifier.prefetch(manifest);
    expect(requests, 1, reason: 'the build that just failed is not re-fetched');

    final newer = UpdateManifest.parse(
      jsonEncode(<String, Object?>{
        'version': '0.1.13+200',
        'build': 200,
        'abi': 'arm64-v8a',
        'url': 'https://mobissh.tailbe5094.ts.net/m-200.apk',
        'sha256': manifest.sha256,
      }),
      manifestUrl: manifestUrl,
    );
    await notifier.prefetch(newer);
    expect(requests, 2);
    expect(c.read(updateDownloadProvider).stage, UpdateStage.ready);
  });

  group('R15 resume after the install-permission grant', () {
    test('needsPermission keeps the file; a resume with the grant hands off '
        'exactly once, with no second download', () async {
      platform.next = UpdateHandoffStatus.needsPermission;
      platform.unmetered = false; // no pre-download: the tap downloads
      final c = makeContainer(
          UpdateCheckResult.available(manifest, installedBuild: 198));
      final notifier = c.read(updateDownloadProvider.notifier);
      await notifier.start(manifest);
      expect(c.read(updateDownloadProvider).stage, UpdateStage.needsPermission);
      expect(requests, 1);

      // Back from the grant screen WITHOUT granting → nothing happens.
      platform.canInstall = false;
      platform.next = UpdateHandoffStatus.launched;
      c.read(lifecycleProvider.notifier).state = AppLifecycleState.inactive;
      c.read(lifecycleProvider.notifier).state = AppLifecycleState.resumed;
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(platform.handedOff, hasLength(1));
      expect(c.read(updateDownloadProvider).stage, UpdateStage.needsPermission);

      // Granted → straight to the installer.
      platform.canInstall = true;
      c.read(lifecycleProvider.notifier).state = AppLifecycleState.inactive;
      c.read(lifecycleProvider.notifier).state = AppLifecycleState.resumed;
      await settle(c, () => c.read(updateDownloadProvider).stage ==
          UpdateStage.handedOff);
      expect(c.read(updateDownloadProvider).stage, UpdateStage.handedOff);
      expect(platform.handedOff, hasLength(2));
      expect(requests, 1, reason: 'the kept verified file is reused');

      // Another resume never hands off again.
      c.read(lifecycleProvider.notifier).state = AppLifecycleState.inactive;
      c.read(lifecycleProvider.notifier).state = AppLifecycleState.resumed;
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(platform.handedOff, hasLength(2));
    });
  });
}
