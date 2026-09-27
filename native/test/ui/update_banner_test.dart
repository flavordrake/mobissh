// #1216 R6/R7/R9/R11/R13 — the banner and the Settings "Updates" section,
// driven by overridden providers (no channel, no network).
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:mobissh/services/self_update.dart';
import 'package:mobissh/state/update_providers.dart';
import 'package:mobissh/ui/update_banner.dart';

final Uri manifestUrl =
    Uri.parse('https://mobissh.tailbe5094.ts.net/android-latest.json');

UpdateManifest manifest({int build = 192}) => UpdateManifest.parse(
  jsonEncode(<String, Object?>{
    'version': '0.1.12-rc.5+$build',
    'build': build,
    'abi': 'arm64-v8a',
    'url': 'https://mobissh.tailbe5094.ts.net/mobissh-native-$build.apk',
    'sha256':
        '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef',
    'builtAt': '2026-09-27T17:29:06Z',
    'notes': '',
  }),
  manifestUrl: manifestUrl,
);

class FixedDownload extends UpdateDownloadNotifier {
  FixedDownload(this.initial);
  final UpdateProgress initial;
  final List<int> started = <int>[];

  @override
  UpdateProgress build() => initial;

  @override
  Future<void> start(UpdateManifest m) async => started.add(m.build);
}

Widget host(
  Widget child, {
  required UpdateCheckResult result,
  UpdateProgress progress = UpdateProgress.idle,
  FixedDownload? download,
}) {
  final dl = download ?? FixedDownload(progress);
  return ProviderScope(
    overrides: [
      updateCheckProvider.overrideWith((ref) async => result),
      installedVersionLabelProvider.overrideWith(
        (ref) async => '0.1.12-rc.4+191',
      ),
      updateDownloadProvider.overrideWith(() => dl),
    ],
    child: MaterialApp(home: Scaffold(body: Column(children: [child]))),
  );
}

void main() {
  group('banner (R7)', () {
    testWidgets('newer build → "Update <installed> → <new>" with Later/Install',
        (tester) async {
      await tester.pumpWidget(host(
        const UpdateBanner(),
        result: UpdateCheckResult.available(manifest(), installedBuild: 191),
      ));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('update-banner')), findsOneWidget);
      expect(
        find.text('Update 0.1.12-rc.4+191 → 0.1.12-rc.5+192'),
        findsOneWidget,
      );
      expect(find.byKey(const Key('update-later')), findsOneWidget);
      expect(find.byKey(const Key('update-install')), findsOneWidget);
    });

    testWidgets('Later hides THIS build for the process lifetime',
        (tester) async {
      await tester.pumpWidget(host(
        const UpdateBanner(),
        result: UpdateCheckResult.available(manifest(), installedBuild: 191),
      ));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('update-later')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('update-banner')), findsNothing);
    });

    testWidgets('Later is per build: a NEWER build is a fresh offer',
        (tester) async {
      final container = ProviderContainer(overrides: [
        updateCheckProvider.overrideWith(
          (ref) async =>
              UpdateCheckResult.available(manifest(build: 193), installedBuild: 191),
        ),
        installedVersionLabelProvider.overrideWith((ref) async => 'x'),
      ]);
      addTearDown(container.dispose);
      container.read(dismissedUpdateBuildProvider.notifier).state = 192;
      await tester.pumpWidget(UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: Scaffold(body: UpdateBanner())),
      ));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('update-banner')), findsOneWidget);
    });

    testWidgets('Install starts the download of the offered build',
        (tester) async {
      final dl = FixedDownload(UpdateProgress.idle);
      await tester.pumpWidget(host(
        const UpdateBanner(),
        result: UpdateCheckResult.available(manifest(), installedBuild: 191),
        download: dl,
      ));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('update-install')));
      await tester.pump();
      expect(dl.started, <int>[192]);
    });

    for (final r in <String, UpdateCheckResult>{
      'up to date': const UpdateCheckResult.upToDate(installedBuild: 192),
      'unreachable (R6 quiet)': const UpdateCheckResult.unreachable(
        'mobissh.tailbe5094.ts.net unreachable',
      ),
      'abi mismatch (R9)': UpdateCheckResult.notOffered(
        'published build is arm64-v8a; this device is x86_64',
        manifest: manifest(),
      ),
      'unsupported (Play / desktop, R13)': const UpdateCheckResult.unsupported(),
    }.entries) {
      testWidgets('no banner when ${r.key}', (tester) async {
        await tester.pumpWidget(host(const UpdateBanner(), result: r.value));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('update-banner')), findsNothing);
      });
    }

    testWidgets(
        'needs permission (R11) → a PERSISTENT message in the banner, not a toast',
        (tester) async {
      await tester.pumpWidget(host(
        const UpdateBanner(),
        result: UpdateCheckResult.available(manifest(), installedBuild: 191),
        progress: const UpdateProgress(
          stage: UpdateStage.needsPermission,
          message: kNeedsInstallPermissionMessage,
        ),
      ));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 10));
      expect(find.byKey(const Key('update-message')), findsOneWidget);
      expect(find.textContaining('install unknown apps'), findsOneWidget);
    });

    testWidgets('a refusal reason is shown (R10)', (tester) async {
      await tester.pumpWidget(host(
        const UpdateBanner(),
        result: UpdateCheckResult.available(manifest(), installedBuild: 191),
        progress: const UpdateProgress(
          stage: UpdateStage.failed,
          message: 'Refused: signing certificate does not match',
        ),
      ));
      await tester.pumpAndSettle();
      expect(find.textContaining('signing certificate'), findsOneWidget);
    });
  });

  group('Settings → Updates (R6/R7/R9)', () {
    testWidgets('available → Installed / Latest lines + Install button',
        (tester) async {
      await tester.pumpWidget(host(
        const UpdateSettingsSection(),
        result: UpdateCheckResult.available(manifest(), installedBuild: 191),
      ));
      await tester.pumpAndSettle();
      expect(find.text('Installed: 0.1.12-rc.4+191'), findsOneWidget);
      expect(find.text('Latest: 0.1.12-rc.5+192'), findsOneWidget);
      expect(find.byKey(const Key('update-settings-install')), findsOneWidget);
    });

    testWidgets('unreachable → "Latest: unreachable — <reason>"',
        (tester) async {
      await tester.pumpWidget(host(
        const UpdateSettingsSection(),
        result: const UpdateCheckResult.unreachable('timed out after 8s'),
      ));
      await tester.pumpAndSettle();
      expect(
        find.text('Latest: unreachable — timed out after 8s'),
        findsOneWidget,
      );
      expect(find.byKey(const Key('update-settings-install')), findsNothing);
    });

    testWidgets('abi mismatch → says why, no Install', (tester) async {
      await tester.pumpWidget(host(
        const UpdateSettingsSection(),
        result: UpdateCheckResult.notOffered(
          'published build is arm64-v8a; this device is x86_64',
          manifest: manifest(),
        ),
      ));
      await tester.pumpAndSettle();
      expect(find.textContaining('this device is x86_64'), findsOneWidget);
      expect(find.byKey(const Key('update-settings-install')), findsNothing);
    });

    testWidgets('up to date', (tester) async {
      await tester.pumpWidget(host(
        const UpdateSettingsSection(),
        result: const UpdateCheckResult.upToDate(installedBuild: 191),
      ));
      await tester.pumpAndSettle();
      expect(find.text('Latest: up to date'), findsOneWidget);
    });

    testWidgets('unsupported (Play build, R13) → the whole section is absent',
        (tester) async {
      await tester.pumpWidget(host(
        const UpdateSettingsSection(),
        result: const UpdateCheckResult.unsupported(),
      ));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('update-settings-section')), findsNothing);
      expect(find.textContaining('Installed:'), findsNothing);
    });
  });
}
