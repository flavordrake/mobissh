// #1216 R6/R7/R9/R11/R13 — the banner and the Settings "Updates" section,
// driven by overridden providers (no channel, no network).
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:mobissh/services/post_update_notice.dart';
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

/// Runs the app-launch post-update flow once, like RootRouter's post-frame.
class _LaunchHook extends ConsumerStatefulWidget {
  const _LaunchHook({super.key});
  @override
  ConsumerState<_LaunchHook> createState() => _LaunchHookState();
}

class _LaunchHookState extends ConsumerState<_LaunchHook> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => showPostUpdateNoticeIfAny(context, ref),
    );
  }

  @override
  Widget build(BuildContext context) => const SizedBox.expand();
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

  group('#1258 fewer taps', () {
    testWidgets('a pre-downloaded build reads "Update ready"', (tester) async {
      await tester.pumpWidget(host(
        const UpdateBanner(),
        result: UpdateCheckResult.available(manifest(), installedBuild: 191),
        progress: const UpdateProgress(stage: UpdateStage.ready),
      ));
      await tester.pumpAndSettle();
      expect(
        find.text('Update ready: 0.1.12-rc.4+191 → 0.1.12-rc.5+192'),
        findsOneWidget,
      );
      expect(find.byKey(const Key('update-progress')), findsNothing);
    });

    testWidgets('session menu row is present while an update is available, '
        'and its tap starts the install', (tester) async {
      final dl = FixedDownload(UpdateProgress.idle);
      var closed = 0;
      await tester.pumpWidget(host(
        UpdateMenuRow(onClose: () => closed++),
        result: UpdateCheckResult.available(manifest(), installedBuild: 191),
        download: dl,
      ));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('session-menu-update')), findsOneWidget);
      expect(find.text('Install update 0.1.12-rc.5+192'), findsOneWidget);
      await tester.tap(find.byKey(const Key('session-menu-update')));
      await tester.pump();
      expect(dl.started, <int>[192]);
      expect(closed, 1);
    });

    for (final r in <String, UpdateCheckResult>{
      'up to date': const UpdateCheckResult.upToDate(installedBuild: 192),
      'unsupported': const UpdateCheckResult.unsupported(),
    }.entries) {
      testWidgets('no session menu row when ${r.key}', (tester) async {
        await tester.pumpWidget(
            host(UpdateMenuRow(onClose: () {}), result: r.value));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('session-menu-update')), findsNothing);
      });
    }

    testWidgets('in-session snackbar appears ONCE per build per process',
        (tester) async {
      final dl = FixedDownload(UpdateProgress.idle);
      final container = ProviderContainer(overrides: [
        updateCheckProvider.overrideWith(
          (ref) async =>
              UpdateCheckResult.available(manifest(), installedBuild: 191),
        ),
        updateDownloadProvider.overrideWith(() => dl),
      ]);
      addTearDown(container.dispose);
      Widget app(bool mounted) => UncontrolledProviderScope(
            container: container,
            child: MaterialApp(
              home: Scaffold(
                body: mounted ? const UpdateSessionOffer() : const SizedBox(),
              ),
            ),
          );
      await tester.pumpWidget(app(true));
      await tester.pumpAndSettle();
      expect(find.text('Update 0.1.12-rc.5+192 available'), findsOneWidget);
      await tester.tap(find.text('Install'));
      await tester.pump();
      expect(dl.started, <int>[192]);
      await tester.pumpAndSettle(const Duration(seconds: 10));

      // A re-check (resume) and a remount (new terminal screen) do not repeat.
      container.invalidate(updateCheckProvider);
      await tester.pumpWidget(app(false));
      await tester.pumpWidget(app(true));
      await tester.pumpAndSettle();
      expect(find.text('Update 0.1.12-rc.5+192 available'), findsNothing);
    });

    testWidgets('no in-session snackbar after Later', (tester) async {
      final container = ProviderContainer(overrides: [
        updateCheckProvider.overrideWith(
          (ref) async =>
              UpdateCheckResult.available(manifest(), installedBuild: 191),
        ),
      ]);
      addTearDown(container.dispose);
      container.read(dismissedUpdateBuildProvider.notifier).state = 192;
      await tester.pumpWidget(UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: Scaffold(body: UpdateSessionOffer())),
      ));
      await tester.pumpAndSettle();
      expect(find.byType(SnackBar), findsNothing);
    });
  });

  group('#1258 post-update snackbar', () {
    Widget app(void Function(BuildContext) onReady) => MaterialApp(
          home: Scaffold(
            body: Builder(builder: (context) {
              WidgetsBinding.instance
                  .addPostFrameCallback((_) => onReady(context));
              return const SizedBox.expand();
            }),
          ),
        );

    testWidgets('"Updated to <version>" + What\'s new opens the saved notes',
        (tester) async {
      var shown = false;
      await tester.pumpWidget(app((context) {
        if (shown) return;
        shown = true;
        showPostUpdateSnackBar(context,
            version: '0.1.13+199', notes: '## v0.1.13\n- Faster updates');
      }));
      await tester.pumpAndSettle();
      expect(find.text('Updated to 0.1.13+199'), findsOneWidget);
      await tester.tap(find.text("What's new"));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('whats-new-sheet')), findsOneWidget);
      expect(find.textContaining('Faster updates'), findsOneWidget);
    });

    // #1271: the notes come from the manifest host. A markdown image must not
    // make the app fetch a URL (Image.network) or render a local file
    // (Image.file); it renders as its alt text.
    testWidgets('images in the notes render as alt text, never loaded',
        (tester) async {
      var shown = false;
      await tester.pumpWidget(app((context) {
        if (shown) return;
        shown = true;
        showPostUpdateSnackBar(context,
            version: '0.1.13+199',
            notes: '- Faster updates\n\n'
                '![beacon pic](https://attacker.example/beacon.png)\n\n'
                '![local pic](/data/data/com.flavordrake.mobissh/x.png)');
      }));
      await tester.pumpAndSettle();
      await tester.tap(find.text("What's new"));
      await tester.pumpAndSettle();
      final sheet = find.byKey(const Key('whats-new-sheet'));
      expect(sheet, findsOneWidget);
      expect(
        find.descendant(of: sheet, matching: find.byType(Image)),
        findsNothing,
        reason: 'no Image.network / Image.file for manifest-supplied notes',
      );
      expect(find.textContaining('beacon pic'), findsOneWidget);
      expect(find.textContaining('local pic'), findsOneWidget);
      expect(find.textContaining('attacker.example'), findsNothing);
    });

    Widget launch(int running) => ProviderScope(
          overrides: [
            runningBuildProvider.overrideWithValue(running),
            installedVersionLabelProvider
                .overrideWith((ref) async => '0.1.13+$running'),
          ],
          child: MaterialApp(home: Scaffold(body: _LaunchHook(key: UniqueKey()))),
        );

    testWidgets('launch flow: shown only when the build increased, once',
        (tester) async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        lastRunPrefKey: '{"v":1,"build":198}',
        pendingPrefKey:
            '{"v":1,"build":199,"version":"0.1.13+199","notes":"- Saved notes"}',
      });
      await tester.pumpWidget(launch(199));
      await tester.runAsync(() => Future<void>.delayed(
          const Duration(milliseconds: 50)));
      await tester.pumpAndSettle();
      expect(find.text('Updated to 0.1.13+199'), findsOneWidget);
      await tester.tap(find.text("What's new"));
      await tester.pumpAndSettle();
      expect(find.textContaining('Saved notes'), findsOneWidget);

      // Relaunch of the same build: nothing.
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(launch(199));
      await tester.runAsync(() => Future<void>.delayed(
          const Duration(milliseconds: 50)));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('post-update-snackbar')), findsNothing);
    });

    testWidgets('launch flow: fresh install → no snackbar', (tester) async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      await tester.pumpWidget(launch(199));
      await tester.runAsync(() => Future<void>.delayed(
          const Duration(milliseconds: 50)));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('post-update-snackbar')), findsNothing);
    });

    testWidgets('no notes → the snackbar has no What\'s new action',
        (tester) async {
      var shown = false;
      await tester.pumpWidget(app((context) {
        if (shown) return;
        shown = true;
        showPostUpdateSnackBar(context, version: '0.1.13+199');
      }));
      await tester.pumpAndSettle();
      expect(find.text('Updated to 0.1.13+199'), findsOneWidget);
      expect(find.text("What's new"), findsNothing);
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
